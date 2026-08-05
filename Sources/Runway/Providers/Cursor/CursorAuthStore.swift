import Foundation

struct CursorAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case sqlite
        case keychain
    }

    var accessToken: String?
    var source: Source
}

enum CursorAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case loginRenewalRequired
    /// The Cursor Keychain item exists but hasn't been loaded this process — the neutral connect
    /// prompt, not a warning.
    case keychainConnectRequired
    /// An attempted manual read of the Cursor Keychain item was denied.
    case keychainPermissionRequired
    case credentialStoreUnreadable

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Sign in via Cursor app or run `agent login`."
        case .loginRenewalRequired:
            return "Cursor login needs renewal. Open the Cursor app (or run `agent login`), then refresh Runway."
        case .keychainConnectRequired:
            return "Cursor login found in Keychain. Connect to load it; if macOS asks, choose Always Allow to avoid future dialogs."
        case .keychainPermissionRequired:
            return "Keychain access to the Cursor login was declined. Refresh and choose Always Allow when macOS asks."
        case .credentialStoreUnreadable:
            return "Cursor login couldn’t be read. Unlock your login keychain and refresh."
        }
    }
}

/// Outcome of a credential load. `connectRequired` means a Cursor Keychain item exists but its
/// secret hasn't been loaded into this process yet — a real login footprint that only an explicit
/// user action may convert into access, and a neutral state (nothing was denied).
enum CursorCredentialLoad: Equatable, Sendable {
    case state(CursorAuthState)
    case connectRequired
    /// An attempted (user-attended) read of the item was denied — the ACL rejects Runway, or the
    /// user declined the dialog. Unlike `connectRequired`, this genuinely needs the user to act.
    case keychainPermissionRequired
    /// The item could not be read for a reason approval cannot fix — a locked login keychain, or
    /// securityd failing. Kept apart from `keychainPermissionRequired` so the card gives advice
    /// that works.
    case unreadable
    case none

    var state: CursorAuthState? {
        guard case .state(let state) = self else { return nil }
        return state
    }
}

struct CursorAuthStore: Sendable {
    static let stateDBPath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let accessTokenKey = "cursorAuth/accessToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    static let keychainAccessTokenService = "cursor-access-token"

    var sqlite: SQLiteAccessing
    var keychain: KeychainReading
    var now: @Sendable () -> Date

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keychain: KeychainReading = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.now = now
    }

    /// Keychain access stays in-process. Automatic refreshes inspect metadata and reuse a manually
    /// seeded cache; only a manual refresh (`allowKeychainInteraction`) may request secret data or
    /// raise the approval prompt.
    func loadCredentials(allowKeychainInteraction: Bool = false) -> CursorCredentialLoad {
        // Only the access token matters: Runway is read-only, so the refresh-token entries (SQLite
        // row and keychain item) are never read — a stale refresh credential must not influence
        // source selection or block a usable access token behind a permission notice.
        let stateValues = readStateValues([Self.accessTokenKey, Self.membershipTypeKey])
        let sqliteAccessToken = stateValues[Self.accessTokenKey]
        let sqliteMembershipType = stateValues[Self.membershipTypeKey]?.lowercased()

        let hasSQLiteAuth = sqliteAccessToken != nil

        // Prompt only when the keychain can actually win source selection: a usable paid SQLite
        // login is returned unconditionally below, so a manual refresh must not raise approval
        // dialogs for stale `agent` keychain entries it would then ignore. An EXPIRED SQLite login
        // is the opposite case — the keychain may hold this same account's still-valid token, which
        // is the only thing that can save the refresh, so it is allowed to ask.
        let sqliteExpired = sqliteAccessToken.map(isExpired) ?? false
        let keychainCanWin = !hasSQLiteAuth || sqliteMembershipType == "free" || sqliteExpired
        // Don't even read when the answer cannot change the outcome. A usable paid SQLite login is
        // returned unconditionally below, and this read is a synchronous securityd round trip — so
        // a wedged securityd would otherwise strand a refresh that had a perfectly good credential
        // in hand. First-run detection takes this path too, with no enclosing deadline at all.
        let accessRead: NonInteractiveKeychainRead = keychainCanWin
            ? readKeychainValue(Self.keychainAccessTokenService, allowInteraction: allowKeychainInteraction)
            : .missing
        let keychainAccessToken = accessRead.trimmedValue

        let hasKeychainAuth = keychainAccessToken != nil

        // Whether the item is confirmed present but unreadable without approval. The existence
        // probe is attributes-only and prompt-free.
        // Non-nil means the keychain item could not be read; the value says whether approval or
        // an unlock is the fix. Either way it is a real login footprint the caller must not skip.
        let unreadableLoad = unreadableItemLoad(accessRead, service: Self.keychainAccessTokenService)

        if hasSQLiteAuth {
            if sqliteMembershipType == "free" {
                // The free-membership preference exists because the keychain (agent CLI) login can
                // be the real paid account. A protected item makes that comparison impossible —
                // silently accepting the free SQLite token could show the wrong account — and a
                // partial keychain pair would fail later as a misleading "token expired". Either
                // way, surface the approval need. A paid SQLite login keeps winning, as it always
                // has.
                if let unreadableLoad {
                    return unreadableLoad
                }
                let sqliteSubject = Self.tokenSubject(sqliteAccessToken)
                let keychainSubject = Self.tokenSubject(keychainAccessToken)
                let subjectsDiffer = sqliteSubject != nil && keychainSubject != nil && sqliteSubject != keychainSubject
                // The agent login usually IS the paid account, so it wins a free SQLite membership
                // — but only while it can still serve a request. Runway can't refresh an expired
                // one, so preferring it there would trade live data for a renewal notice.
                if hasKeychainAuth,
                   subjectsDiffer,
                   let keychainAccessToken,
                   !isExpired(keychainAccessToken) {
                    return .state(CursorAuthState(accessToken: keychainAccessToken, source: .keychain))
                }
            }

            // Read-only means a lapsed selected token ends the refresh, so prefer a usable token
            // from the other source when it provably belongs to the SAME account. Requiring both
            // subjects to be known and equal keeps this from ever crossing accounts — which source
            // wins between DIFFERENT accounts stays governed by the membership rule above.
            if let sqliteAccessToken,
               let keychainAccessToken,
               isExpired(sqliteAccessToken),
               !isExpired(keychainAccessToken),
               let subject = Self.tokenSubject(sqliteAccessToken),
               subject == Self.tokenSubject(keychainAccessToken)
            {
                return .state(CursorAuthState(accessToken: keychainAccessToken, source: .keychain))
            }

            // The selected token is dead and a protected item may hold a live one for this account.
            // Asking for approval is actionable; reporting renewal here would not be, because the
            // usable credential is exactly the one Runway cannot read yet.
            if sqliteExpired, let unreadableLoad {
                return unreadableLoad
            }

            return .state(CursorAuthState(accessToken: sqliteAccessToken, source: .sqlite))
        }

        // A protected item is a real login footprint (`hasLocalCredentials` must see it); only a
        // manual refresh may convert it into access.
        if let unreadableLoad {
            return unreadableLoad
        }

        if hasKeychainAuth {
            return .state(CursorAuthState(accessToken: keychainAccessToken, source: .keychain))
        }
        return .none
    }

    /// A live token for the SAME account from whichever source was not selected. Runway cannot
    /// refresh a rejected Cursor token, but the app and the `agent` CLI keep separate copies and one
    /// can outlive the other — so a revoked-but-unexpired selection should not strand a working
    /// credential. Subject equality is required, so this can never cross accounts.
    func sameAccountAlternative(
        to state: CursorAuthState,
        allowKeychainInteraction: Bool = false
    ) -> CursorCredentialLoad {
        guard let current = state.accessToken, let subject = Self.tokenSubject(current) else {
            return .none
        }
        let candidate: String?
        let source: CursorAuthState.Source
        switch state.source {
        case .sqlite:
            let read = readKeychainValue(
                Self.keychainAccessTokenService,
                allowInteraction: allowKeychainInteraction
            )
            // An unreadable alternative is NOT "no alternative": the rejected selection may well be
            // dead while this protected item holds the live token, so ask for approval rather than
            // telling the user to sign in again.
            if let load = unreadableItemLoad(read, service: Self.keychainAccessTokenService) {
                return load
            }
            candidate = read.trimmedValue
            source = .keychain
        case .keychain:
            candidate = readStateValues([Self.accessTokenKey])[Self.accessTokenKey]
            source = .sqlite
        }
        guard let candidate,
              candidate != current,
              Self.tokenSubject(candidate) == subject,
              !isExpired(candidate)
        else {
            return .none
        }
        return .state(CursorAuthState(accessToken: candidate, source: source))
    }

    /// `nil` from the probe means "cannot check" (locked keychain, stuck flight), not "absent" —
    /// treating it as logged-out would silently swallow an access problem. Only a confirmed-absent
    /// item reads as no footprint.
    private func protectedItemExists(_ read: NonInteractiveKeychainRead, service: String) -> Bool {
        switch unreadableItemLoad(read, service: service) {
        case .connectRequired, .keychainPermissionRequired: return true
        default: return false
        }
    }

    /// Which failure an `.unavailable` read was, or nil when the item is provably absent. The
    /// read's own status is the evidence; the probe is the fallback for when none was recorded,
    /// where nil still means "cannot check" rather than "absent".
    private func unreadableItemLoad(
        _ read: NonInteractiveKeychainRead,
        service: String
    ) -> CursorCredentialLoad? {
        guard read == .unavailable else { return nil }
        switch keychain.lastReadFailure(service: service) {
        case .manualReadDeferred?:
            return .connectRequired
        case .permissionDenied?:
            return .keychainPermissionRequired
        case .unreadable?:
            return .unreadable
        case nil:
            // No verdict recorded: UI-gate contention leaves none by design, and the probe behind
            // that same gate answers nil too. A confirmed-present item was simply never read (a
            // deferral, not a denial), an unexamined one reports unreadable, and only a confirmed
            // absence is no footprint.
            switch keychain.genericPasswordExists(service: service) {
            case true?: return .connectRequired
            case nil: return .unreadable
            case false?: return nil
            }
        }
    }

    /// Whether the token's own JWT `exp` has lapsed. Runway never refreshes a Cursor token — the
    /// Cursor app owns rotation — so an expired token is reported for renewal, not renewed. Unknown
    /// expiry is not "expired": the usage call decides.
    func isExpired(_ accessToken: String) -> Bool {
        guard let expiresAt = Self.tokenExpiration(accessToken) else { return false }
        return expiresAt <= now()
    }

    /// All requested keys in one query. `json_group_object` folds the matching rows into a single
    /// JSON object value, so the one-value `queryValue` contract still fits; a missing key is
    /// simply absent from the object, and no rows at all yields NULL (→ empty dictionary), the
    /// same nil-per-key result the per-key reads produced. Values come back trimmed.
    private func readStateValues(_ keys: [String]) -> [String: String] {
        let list = keys.map { "'\(Self.sqlEscaped($0))'" }.joined(separator: ", ")
        let sql = "SELECT json_group_object(key, value) FROM ItemTable WHERE key IN (\(list));"
        guard let raw = try? sqlite.queryValue(path: Self.stateDBPath, sql: sql),
              let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String]
        else { return [:] }
        var values: [String: String] = [:]
        for (key, value) in object {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { values[key] = trimmed }
        }
        return values
    }

    private func readKeychainValue(_ service: String, allowInteraction: Bool) -> NonInteractiveKeychainRead {
        guard allowInteraction else {
            return keychain.readGenericPasswordWithoutUserInteraction(service: service)
        }
        do {
            guard let value = try keychain.readGenericPasswordAllowingUserInteraction(service: service) else {
                return .missing
            }
            return .value(value)
        } catch {
            return .unavailable
        }
    }

    fileprivate static func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func tokenExpiration(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func tokenSubject(_ token: String?) -> String? {
        guard let token,
              let subject = ProviderParse.jwtPayload(token)?["sub"] as? String
        else {
            return nil
        }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

private extension NonInteractiveKeychainRead {
    /// The read value trimmed to nil-if-empty, matching Cursor's historical normalization.
    var trimmedValue: String? {
        guard case .value(let value) = self else { return nil }
        return CursorAuthStore.trimmed(value)
    }
}
