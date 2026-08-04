import CryptoKit
import Foundation

struct ClaudeOAuth: Codable, Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Double?
    var subscriptionType: String?
    var rateLimitTier: String?
    var scopes: [String]?
}

struct ClaudeCredentialsFile: Codable, Hashable, Sendable {
    var claudeAiOauth: ClaudeOAuth?
}

struct ClaudeCredentialState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case file
        case keychainCurrentUser(service: String)
        case keychainLegacy(service: String)
        case desktop
        case environment

        /// Log-safe source kind — NEVER the keychain service name or any token.
        var label: String {
            switch self {
            case .file: "file"
            case .keychainCurrentUser: "keychainCurrentUser"
            case .keychainLegacy: "keychainLegacy"
            case .desktop: "desktop"
            case .environment: "environment"
            }
        }
    }

    var oauth: ClaudeOAuth
    var source: Source
    var inferenceOnly: Bool
    /// The account's CURRENT plan family and rate-limit tier from Claude Code's state file
    /// (`.claude.json`), when the scope has one. The credential blob's copies are written at login and
    /// never updated on a plan change, so after an upgrade the blob keeps saying e.g. `…_5x` (or `pro`)
    /// while the profile Claude Code refetches regularly says `…_20x` (`claude_max`).
    var profileSubscriptionType: String? = nil
    var profileRateLimitTier: String? = nil

    /// The credential values the plan badge is built from: the login blob with its plan family and
    /// rate-limit tier replaced by the fresher state-file values when they are known.
    var displayOAuth: ClaudeOAuth {
        var display = oauth
        if let profileSubscriptionType {
            // A trusted profile family brings the profile's tier with it as one snapshot — even when
            // that tier is absent (a Max → Pro downgrade nulls it): keeping the blob's old multiplier
            // would pair values from two points in time and render a contradictory "Pro 20x".
            display.subscriptionType = profileSubscriptionType
            display.rateLimitTier = profileRateLimitTier
        } else if let profileRateLimitTier {
            display.rateLimitTier = profileRateLimitTier
        }
        return display
    }

    /// Whether this candidate carries a non-blank access token — the single definition of "usable"
    /// shared by `refresh()`'s candidate filter and `hasLocalCredentials()`'s first-run detection, so
    /// the two can never drift.
    var hasUsableAccessToken: Bool {
        oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// A token-free, log-safe one-line descriptor for diagnosing auth failures from a default-level
    /// (info) log: the source kind plus whether its access token is already expired (`expiresAt`,
    /// epoch ms, vs `now`). NEVER includes any token value or the credential blob. Runway never
    /// refreshes a Claude token, so `expired=yes` explains exactly why a candidate was skipped and
    /// the login-renewal notice shown.
    func diagnosticsLabel(now: Date) -> String {
        let expired: String
        if let expiresAt = oauth.expiresAt {
            expired = expiresAt <= now.timeIntervalSince1970 * 1000 ? "yes" : "no"
        } else {
            expired = "unknown"
        }
        return "\(source.label) expired=\(expired)"
    }
}

/// Whether Claude Code's higher-priority Keychain sources were conclusively checked. Automatic
/// callers never interact with Keychain UI: a protected item is reported as `.permissionRequired`,
/// while a locked/denied attributes probe is `.unavailable` because item existence is unknown.
enum ClaudeKeychainAccessStatus: Equatable, Sendable {
    case resolved
    case permissionRequired
    case unavailable

    mutating func recordUnreadableItem(exists: Bool?) {
        switch exists {
        case true:
            self = .permissionRequired
        case false:
            break
        case nil:
            if self == .resolved {
                self = .unavailable
            }
        }
    }
}

struct ClaudeCredentialLoad: Sendable {
    var candidates: [ClaudeCredentialState]
    var desktopStatus: ClaudeDesktopCredentialStatus
    /// Automatic refreshes carry protected or inconclusive Keychain state to the provider instead of
    /// opening a macOS password dialog or silently selecting a lower-priority credential.
    var keychainAccessStatus: ClaudeKeychainAccessStatus
}

enum ClaudeAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case codePermissionRequired
    case codeCredentialsUnavailable
    case desktopPermissionRequired
    case desktopTokenExpired
    case desktopCredentialsUnavailable
    case loginRenewalRequired
    case invalidOAuthURL(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `claude` to authenticate."
        case .codePermissionRequired:
            return "Claude Code login found. Refresh manually and choose Always Allow to connect it."
        case .codeCredentialsUnavailable:
            return "Claude Code credentials couldn't be checked. Unlock your login keychain, then refresh."
        case .desktopPermissionRequired:
            return "Claude Desktop login found. Refresh once and choose Always Allow to connect it."
        case .desktopTokenExpired:
            return "Claude Desktop login is stale. Open Claude Desktop, then refresh Runway."
        case .desktopCredentialsUnavailable:
            return "Claude Desktop login couldn't be read. Open Claude Desktop, then try again."
        case .loginRenewalRequired:
            return "Claude login needs renewal. Open Claude Code, then refresh Runway."
        case .invalidOAuthURL(let value):
            return "Invalid Claude OAuth URL: \(value). Check CLAUDE_CODE_CUSTOM_OAUTH_URL / CLAUDE_LOCAL_OAUTH_API_BASE."
        }
    }

    /// Whether a failure on one credential source should fall through to the next one rather than
    /// failing the whole refresh. An expired/revoked token in the preferred source (a stale keychain
    /// entry from a prior login that later "locked out") must not shadow a fresh token an external
    /// `claude` re-login wrote to a different source — so the token-is-bad cases allow a fallback,
    /// while "no credentials at all" does not (there is nothing better to try). Mirrors
    /// `CodexAuthError.allowsAuthFallback`.
    var allowsAuthFallback: Bool {
        switch self {
        case .loginRenewalRequired, .desktopTokenExpired:
            return true
        case .notLoggedIn, .codePermissionRequired, .codeCredentialsUnavailable, .desktopPermissionRequired,
             .desktopCredentialsUnavailable, .invalidOAuthURL:
            return false
        }
    }

    /// The renewal cases where Runway still has a login on file but its token has lapsed. The provider
    /// degrades these to a header warning over the local spend tiles instead of a hard error card:
    /// Runway is a read-only consumer of Claude's credentials, so the fix is always "open the owning
    /// Claude app", never a Runway-side action.
    var isLoginRenewal: Bool {
        switch self {
        case .loginRenewalRequired, .desktopTokenExpired:
            return true
        default:
            return false
        }
    }
}

/// Which login a `ClaudeAuthStore` is allowed to see. `.standard` is the default card —
/// byte-identical to the store's historical behavior. `.configDir` backs an extra account card and
/// deliberately has no cross-account, environment-token, or Desktop fallback: the card can only ever
/// read the one login it was created for.
enum ClaudeCredentialScope: Hashable, Sendable {
    case standard
    /// One extra `CLAUDE_CONFIG_DIR` home. `keychainLiteral` is the literal string whose hash names
    /// the keychain item (Claude Code hashes the env value as typed — `~/…` vs absolute differ).
    case configDir(path: String, keychainLiteral: String)
}

struct ClaudeAuthStore: Sendable {
    /// Shared with `ClaudeProfilePlanReader`, which resolves the state file against the same home.
    static let defaultClaudeHome = "~/.claude"
    private static let credentialFileName = ".credentials.json"
    private static let keychainServicePrefix = "Claude Code"
    private static let prodBaseAPIURL = "https://api.anthropic.com"

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainReading
    var desktop: ClaudeDesktopAuthStore
    var now: @Sendable () -> Date
    let scope: ClaudeCredentialScope
    /// Whether the `.standard` store may fall back to Claude Desktop's credentials. On by default
    /// (the historical behavior); the catalog turns it OFF once extra Claude account cards exist,
    /// because the Desktop login could belong to any of them — borrowing it unpinned could fetch one
    /// account's usage onto another account's card. Desktop-backed cards return properly in Phase 3.
    let allowsDesktopFallback: Bool

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainReading = SecurityKeychainAccessor(),
        desktop: ClaudeDesktopAuthStore? = nil,
        scope: ClaudeCredentialScope = .standard,
        allowsDesktopFallback: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.desktop = desktop ?? ClaudeDesktopAuthStore(files: files, now: now)
        self.scope = scope
        self.allowsDesktopFallback = allowsDesktopFallback
        self.now = now
    }

    /// All credential sources currently on disk/keychain, in fixed keychain-before-file order, for the
    /// refresh loop to try in order. The provider probes each and — on an auth-expiry error
    /// (`ClaudeAuthError.allowsAuthFallback`) — falls through to the next, so an external `claude`
    /// re-login is picked up no matter which source it lands in, even when a stale/locked-out token still
    /// sits in another. Re-read on every refresh; nothing is cached in memory. Keychain interaction is
    /// opt-in so a new caller cannot accidentally introduce a launch-time password dialog.
    func loadCredentialSet(
        allowKeychainInteraction: Bool = false,
        allowDesktopInteraction: Bool = false,
        forceDesktopFallback: Bool = false,
        includeProfileTier: Bool = true
    ) -> ClaudeCredentialLoad {
        let storedLoad = orderedStoredCandidates(allowKeychainInteraction: allowKeychainInteraction)
        var stored = storedLoad.candidates
        // The state file describes ONE login — the one Claude Code last wrote, which also lands in
        // the highest-priority stored source (keychain first). Only that candidate gets the profile
        // plan for its badge: a lower-priority fallback candidate can be a DIFFERENT account (the
        // refresh fall-through exists for exactly that case) and must keep its own blob metadata
        // rather than wear another account's plan. The Desktop candidate (inserted below) likewise
        // keeps its own. A refresh landing between a re-login's two writes (credentials before state
        // file) can pair them across accounts for ONE cycle; that transient is accepted — the blob
        // carries no account id to verify against, and both stores converge once the login completes.
        // If a re-login instead lands in the lower-priority FILE beside a still-valid keychain login,
        // the state file (and with it the card's whole identity, per DefaultAccountObserver) already
        // describes the file account while usage comes from the keychain — the badge matching the
        // card label there is the consistent choice, and a failed keychain login falls through to the
        // file account's own freshly-written blob. Generation snapshots opt out: their candidates
        // keep only oauth + source, so the state-file read would be pure overhead there.
        if includeProfileTier, !stored.isEmpty,
           let plan = ClaudeProfilePlanReader(environment: environment, files: files, scope: scope).read()
        {
            stored[0].profileSubscriptionType = plan.subscriptionType
            stored[0].profileRateLimitTier = plan.rateLimitTier
        }
        var desktopStatus: ClaudeDesktopCredentialStatus = .notChecked
        // A working CLI login remains the source of truth and avoids a second Keychain prompt. Desktop
        // is a fallback for people who only use the native app (or whose stored CLI login lacks profile
        // scope), never a competing account source. A `.configDir` card never consults Desktop at all —
        // that login belongs to another card.
        let desktopAllowed = scope == .standard && allowsDesktopFallback
        if forceDesktopFallback, !desktopAllowed {
            // Tell the provider there is no safe Desktop candidate so it preserves the original CLI
            // auth error instead of converting it to a generic "not logged in" result.
            desktopStatus = .notFound
        }
        let hasUsableCLILogin = stored.contains {
            $0.hasUsableAccessToken && liveUsageAvailability($0) == .available
        }
        // Once Claude Code access is unresolved, its higher-priority result will win in the provider.
        // Do not continue into Desktop: on a manual refresh that could open a second, irrelevant
        // Safe Storage dialog after the user just denied or cancelled the Claude Code prompt.
        if storedLoad.keychainAccessStatus == .resolved,
           desktopAllowed,
           forceDesktopFallback || !hasUsableCLILogin
        {
            let result = desktop.load(allowInteraction: allowDesktopInteraction)
            desktopStatus = result.status
            if let oauth = result.oauth {
                stored.insert(ClaudeCredentialState(
                    oauth: oauth,
                    source: .desktop,
                    inferenceOnly: false
                ), at: 0)
            }
        }

        let candidates = applyingEnvironmentToken(to: stored)
        return ClaudeCredentialLoad(
            candidates: candidates,
            desktopStatus: desktopStatus,
            keychainAccessStatus: storedLoad.keychainAccessStatus
        )
    }

    func loadCredentialCandidates() -> [ClaudeCredentialState] {
        loadCredentialSet().candidates
    }

    /// Whether this scoped card has a credential refresh can actually start with. Standard detection
    /// uses the same loaders and usability filters as refresh, with all Keychain interaction forbidden.
    func hasCredentialFootprint() -> Bool {
        switch scope {
        case .standard:
            let load = loadCredentialSet(includeProfileTier: false)
            switch load.keychainAccessStatus {
            case .permissionRequired:
                // The attributes probe confirmed a protected Claude Code item. It is a real footprint
                // even though only an explicit manual refresh may ask the user to approve it.
                return true
            case .unavailable:
                // Item existence is unknown, so do not enable from a lower-priority source that refresh
                // would refuse to use.
                return false
            case .resolved:
                break
            }
            if load.candidates.contains(where: \.hasUsableAccessToken) {
                return true
            }
            switch load.desktopStatus {
            case .available, .permissionRequired, .stale:
                return true
            case .notChecked, .notFound, .invalid:
                return false
            }
        case .configDir:
            if files.exists(credentialsPath()) { return true }
            return keychainServiceCandidates().contains {
                keychain.genericPasswordExists(service: $0) == true
            }
        }
    }

    private func applyingEnvironmentToken(to stored: [ClaudeCredentialState]) -> [ClaudeCredentialState] {
        // An ambient env token describes the DEFAULT login's environment; a scoped card must never
        // inherit it (that would leak one account's token into another account's card).
        guard case .standard = scope else { return stored }
        guard let envAccessToken = envText("CLAUDE_CODE_OAUTH_TOKEN") else {
            return stored
        }
        // An explicit `CLAUDE_CODE_OAUTH_TOKEN` is inference-only (typically a `claude setup-token`
        // token): it can run the model but 403s on the usage endpoint. It also reaches us when the user
        // only *ambiently* has it exported — Runway captures the login-shell environment — so it must
        // not shadow a real interactive login that CAN read usage. Prefer any stored login able to fetch
        // live usage (keychain-first, then file) for the usage call, with the env token kept as a
        // trailing inference-only fallback for the refresh loop. With no live-capable stored login (a
        // genuinely headless setup) the env token is the only candidate — unchanged: spend tiles still
        // load. Nothing is silenced; only the credential SELECTED for the usage fetch changes.
        let liveCapable = stored.filter { liveUsageAvailability($0) == .available }
        // Borrow plan metadata (subscription type / scopes) for display from the credential actually
        // preferred — the live-capable login when there is one, else the first stored login — so the
        // fallback doesn't inherit metadata from a login we decided not to use. Source it honestly as
        // `.environment`: the token came from the env, so the refresh-start diagnostics name the real
        // source when the loop falls back to it.
        let base = liveCapable.first ?? stored.first
        var oauth = base?.oauth ?? ClaudeOAuth()
        oauth.accessToken = envAccessToken
        let envCandidate = ClaudeCredentialState(
            oauth: oauth,
            source: .environment,
            inferenceOnly: true,
            profileSubscriptionType: base?.profileSubscriptionType,
            profileRateLimitTier: base?.profileRateLimitTier
        )
        return liveCapable.isEmpty ? [envCandidate] : liveCapable + [envCandidate]
    }

    /// Whether the access token's own expiry stamp has lapsed. Runway never refreshes a Claude
    /// token — Claude Code owns rotation — so an expired candidate is skipped, not renewed.
    func isExpired(_ oauth: ClaudeOAuth) -> Bool {
        guard let expiresAt = oauth.expiresAt else { return false }
        return expiresAt <= now().timeIntervalSince1970 * 1000
    }

    /// Why the live-usage endpoint (`/api/oauth/usage`, which backs Session / Weekly / Sonnet / Extra
    /// Usage) can or can't be called for a credential. Reading usage requires the `user:profile` scope,
    /// so a token that only carries `user:inference` (e.g. one minted by `claude setup-token`) can't —
    /// and the provider surfaces that as a friendly "re-login" notice instead of silently blank bars.
    enum LiveUsageAvailability: Equatable, Sendable {
        case available
        /// An explicit `CLAUDE_CODE_OAUTH_TOKEN`: inference-only by design, so there's nothing to fetch
        /// and nothing to nag about — the spend tiles still load from local logs.
        case inferenceOnlyToken
        /// A stored login whose granted scopes lack `user:profile`. The usage endpoint would reject it,
        /// so the session/weekly bars can't load until the user signs in again with `claude`.
        case missingProfileScope
    }

    /// The required scope for the usage endpoint. A credential missing it can authenticate for inference
    /// but can't read subscription usage windows.
    static let usageScope = "user:profile"

    func liveUsageAvailability(_ state: ClaudeCredentialState) -> LiveUsageAvailability {
        if state.inferenceOnly { return .inferenceOnlyToken }
        // Older credentials predate the scopes field; treat an absent/empty list as "unknown, allow" so
        // we don't suppress usage for tokens that actually carry the access (and would 403 loudly if not).
        guard let scopes = state.oauth.scopes, !scopes.isEmpty else { return .available }
        return scopes.contains(Self.usageScope) ? .available : .missingProfileScope
    }

    func claudeHomeOverride() -> String? {
        envText("CLAUDE_CONFIG_DIR")
    }

    // Resolved OAuth endpoint strings before URL validation. The suffix is derived from the same
    // env-var branching as the base URL but never depends on URL validity, so the (non-throwing)
    // keychain candidate path can read it without risking a throw.
    private struct ResolvedOAuthEndpoints {
        var baseAPI: String
        var suffix: String
    }

    private func resolveOAuthEndpoints() -> ResolvedOAuthEndpoints {
        Self.resolveOAuthEndpoints(environment: environment)
    }

    private static func resolveOAuthEndpoints(environment: EnvironmentReading) -> ResolvedOAuthEndpoints {
        var baseAPI = Self.prodBaseAPIURL
        var suffix = ""

        let isAntUser = envText(environment, "USER_TYPE") == "ant"
        if isAntUser, envFlag(environment, "USE_LOCAL_OAUTH") {
            baseAPI = (envText(environment, "CLAUDE_LOCAL_OAUTH_API_BASE") ?? "http://localhost:8000").trimmingTrailingSlashes
            suffix = "-local-oauth"
        } else if isAntUser, envFlag(environment, "USE_STAGING_OAUTH") {
            baseAPI = "https://api-staging.anthropic.com"
            suffix = "-staging-oauth"
        }

        if let custom = envText(environment, "CLAUDE_CODE_CUSTOM_OAUTH_URL") {
            baseAPI = custom.trimmingTrailingSlashes
            suffix = "-custom-oauth"
        }

        return ResolvedOAuthEndpoints(baseAPI: baseAPI, suffix: suffix)
    }

    /// The keychain service names as this environment's Claude Code writes them — the single source
    /// both the scoped store and config-dir DISCOVERY build from, so a non-prod OAuth setup (local/
    /// staging/custom, which suffixes the service) can never make discovery probe one name while
    /// refresh reads another.
    static func baseKeychainServiceName(environment: EnvironmentReading) -> String {
        "\(keychainServicePrefix)\(resolveOAuthEndpoints(environment: environment).suffix)-credentials"
    }

    static func scopedKeychainServiceName(forConfigDirLiteral literal: String, environment: EnvironmentReading) -> String {
        "\(baseKeychainServiceName(environment: environment))-\(hashSuffix(literal))"
    }

    /// The exact keychain services a standard-scope store probes, shared with default-account
    /// observation so a keychain-only login is never mistaken for an absent default source.
    static func standardKeychainServiceCandidates(
        environment: EnvironmentReading,
        configDirOverride: String?
    ) -> [String] {
        let base = baseKeychainServiceName(environment: environment)
        guard let configDirOverride else { return [base] }
        return [
            scopedKeychainServiceName(
                forConfigDirLiteral: configDirOverride,
                environment: environment
            ),
            base,
        ]
    }

    // The base API can derive from user-set env vars (CLAUDE_CODE_CUSTOM_OAUTH_URL,
    // CLAUDE_LOCAL_OAUTH_API_BASE). A malformed value is a system-boundary input that must fail
    // loudly — never force-unwrap (crashes the app) and never silently fall back to prod (that hides
    // the misconfiguration and would send the user's token to production).
    func usageEndpoint() throws -> URL {
        let usageURLString = "\(resolveOAuthEndpoints().baseAPI)/api/oauth/usage"
        guard let usageURL = URL(string: usageURLString) else {
            throw ClaudeAuthError.invalidOAuthURL(usageURLString)
        }
        return usageURL
    }

    func keychainServiceCandidates() -> [String] {
        // Only needs the file suffix, which never fails — keep this off the throwing URL path so
        // credential loading stays forgiving even when a custom OAuth URL is malformed.
        let base = "\(Self.keychainServicePrefix)\(resolveOAuthEndpoints().suffix)-credentials"
        switch scope {
        case .configDir(_, let keychainLiteral):
            // Exactly this card's item — never the bare default service, which is another account's
            // login.
            return ["\(base)-\(hashSuffix(keychainLiteral))"]
        case .standard:
            return Self.standardKeychainServiceCandidates(
                environment: environment,
                configDirOverride: claudeHomeOverride()
            )
        }
    }

    static func parseCredentials(_ text: String) -> ClaudeCredentialsFile? {
        ProviderParse.decodeJSONWithHexFallback(text, as: ClaudeCredentialsFile.self)
    }

    /// The single file/keychain usability rule: the payload must parse and carry a nonblank access
    /// token. Discovery and identity attribution use this too, so an unusable leftover credential
    /// can never name an ambient-token runtime that refresh itself would reject.
    static func parseUsableCredentials(_ text: String) -> ClaudeCredentialsFile? {
        guard let parsed = parseCredentials(text),
              let token = parsed.claudeAiOauth?.accessToken,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return parsed
    }

    /// Keychain and file credentials in fixed keychain-before-file order. The keychain is Claude Code's
    /// source of truth on macOS — recent versions keep the current session there and can leave a stale
    /// `~/.claude/.credentials.json` behind — so it must win when valid; the file is only a fallback
    /// (older installs / Linux-style layouts). The refresh loop still falls through to the file on an
    /// auth-expiry error, so a fresh external `claude` re-login that landed in the other source is picked
    /// up (#687) WITHOUT letting a stale file outrank the live keychain just because its token carries a
    /// later expiry (the #738 regression from ranking purely by expiry). The source kind (never the
    /// token) is logged so a "locked out" report can be diagnosed from which source was chosen.
    private struct StoredCandidateLoad {
        var candidates: [ClaudeCredentialState]
        var keychainAccessStatus: ClaudeKeychainAccessStatus
    }

    private func orderedStoredCandidates(allowKeychainInteraction: Bool) -> StoredCandidateLoad {
        var candidates: [ClaudeCredentialState] = []
        let keychainLoad = loadKeychainCredentials(allowInteraction: allowKeychainInteraction)
        if let keychain = keychainLoad.state { candidates.append(keychain) }
        if let file = loadFileCredentials() { candidates.append(file) }

        if candidates.count > 1 {
            let labels = candidates.map(\.source.label).joined(separator: ", ")
            AppLog.debug(LogTag.auth("claude"), "credential candidates (keychain first): \(labels)")
        } else if let only = candidates.first {
            AppLog.debug(LogTag.auth("claude"), "credential source: \(only.source.label)")
        }
        return StoredCandidateLoad(
            candidates: candidates,
            keychainAccessStatus: keychainLoad.accessStatus
        )
    }

    private func loadFileCredentials() -> ClaudeCredentialState? {
        let path = credentialsPath()
        guard files.exists(path),
              let text = try? files.readText(path),
              let parsed = Self.parseUsableCredentials(text),
              let oauth = parsed.claudeAiOauth
        else {
            return nil
        }
        return ClaudeCredentialState(oauth: oauth, source: .file, inferenceOnly: false)
    }

    private struct KeychainCredentialLoad {
        var state: ClaudeCredentialState?
        var accessStatus: ClaudeKeychainAccessStatus
    }

    private func loadKeychainCredentials(allowInteraction: Bool) -> KeychainCredentialLoad {
        // The service name is safe to log; NEVER log the returned credential blob / OAuth tokens.
        var accessStatus: ClaudeKeychainAccessStatus = .resolved
        for service in keychainServiceCandidates() {
            var serviceReadUnavailable = false
            let currentUserValue: String?
            if allowInteraction {
                do {
                    currentUserValue = try keychain
                        .readGenericPasswordForCurrentUserAllowingUserInteraction(service: service)
                } catch {
                    currentUserValue = nil
                    serviceReadUnavailable = true
                }
            } else {
                switch keychain.readGenericPasswordForCurrentUserWithoutUserInteraction(service: service) {
                case .value(let value):
                    currentUserValue = value
                case .missing:
                    currentUserValue = nil
                case .unavailable:
                    currentUserValue = nil
                    serviceReadUnavailable = true
                }
            }
            if serviceReadUnavailable {
                // Probe the SAME item the read just failed on (service + current user), so this
                // joins that read's flight and sees its breaker instead of starting an unrelated
                // service-wide query behind it.
                let exists = keychain.genericPasswordForCurrentUserExists(service: service)
                accessStatus.recordUnreadableItem(exists: exists)
                if allowInteraction {
                    return KeychainCredentialLoad(state: nil, accessStatus: accessStatus)
                }
                // Never broaden past a protected (or uncheckable) exact item, the same rule Codex
                // and Copilot follow: the service-wide read is another Security call behind the
                // very wedge this is containing, and with several items it could select a different
                // account's login. The provider already refuses lower-priority credentials once the
                // status is permissionRequired/unavailable, so nothing is lost by stopping here.
                if exists != false {
                    return KeychainCredentialLoad(state: nil, accessStatus: accessStatus)
                }
            }

            if let state = credentialState(
                from: currentUserValue,
                service: service,
                source: .keychainCurrentUser(service: service)
            ) {
                return KeychainCredentialLoad(state: state, accessStatus: accessStatus)
            }

            serviceReadUnavailable = false
            let legacyValue: String?
            if allowInteraction {
                do {
                    legacyValue = try keychain.readGenericPasswordAllowingUserInteraction(service: service)
                } catch {
                    legacyValue = nil
                    serviceReadUnavailable = true
                }
            } else {
                switch keychain.readGenericPasswordWithoutUserInteraction(service: service) {
                case .value(let value):
                    legacyValue = value
                case .missing:
                    legacyValue = nil
                case .unavailable:
                    legacyValue = nil
                    serviceReadUnavailable = true
                }
            }
            if serviceReadUnavailable {
                accessStatus.recordUnreadableItem(
                    exists: keychain.genericPasswordExists(service: service)
                )
                if allowInteraction {
                    return KeychainCredentialLoad(state: nil, accessStatus: accessStatus)
                }
            }
            if let state = credentialState(
                from: legacyValue,
                service: service,
                source: .keychainLegacy(service: service)
            ) {
                return KeychainCredentialLoad(state: state, accessStatus: accessStatus)
            }
            AppLog.debug(.keychain, "read miss service=\(service)")
        }
        return KeychainCredentialLoad(state: nil, accessStatus: accessStatus)
    }

    /// Parse one keychain hit into a credential state, or `nil` if it's absent / malformed / tokenless.
    /// Shared by the current-user and legacy reads so they don't repeat the parse-guard-log-build block;
    /// the keychain read itself stays at the call site to preserve the read order and error-swallowing.
    private func credentialState(
        from value: String?,
        service: String,
        source: ClaudeCredentialState.Source
    ) -> ClaudeCredentialState? {
        guard let value,
              let parsed = Self.parseUsableCredentials(value),
              let oauth = parsed.claudeAiOauth
        else {
            return nil
        }
        AppLog.debug(.keychain, "read hit service=\(service)")
        return ClaudeCredentialState(oauth: oauth, source: source, inferenceOnly: false)
    }

    private func credentialsPath() -> String {
        if case .configDir(let path, _) = scope {
            return "\(path)/\(Self.credentialFileName)"
        }
        return "\(envText("CLAUDE_CONFIG_DIR") ?? Self.defaultClaudeHome)/\(Self.credentialFileName)"
    }

    private func envText(_ name: String) -> String? {
        Self.envText(environment, name)
    }

    private static func envText(_ environment: EnvironmentReading, _ name: String) -> String? {
        guard let value = environment.value(for: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func envFlag(_ name: String) -> Bool {
        Self.envFlag(environment, name)
    }

    private static func envFlag(_ environment: EnvironmentReading, _ name: String) -> Bool {
        guard let value = envText(environment, name)?.lowercased() else { return false }
        return !["0", "false", "no", "off"].contains(value)
    }

    private func hashSuffix(_ value: String) -> String {
        Self.hashSuffix(value)
    }

    private static func hashSuffix(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }
}
