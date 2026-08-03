import Foundation

struct CursorAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case sqlite
        case keychain
    }

    var accessToken: String?
    var refreshToken: String?
    var source: Source
}

enum CursorAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case tokenExpired
    case keychainPermissionRequired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Sign in via Cursor app or run `agent login`."
        case .sessionExpired:
            return "Session expired. Sign in via Cursor app or run `agent login`."
        case .tokenExpired:
            return "Token expired. Sign in via Cursor app or run `agent login`."
        case .keychainPermissionRequired:
            return "Cursor login found in Keychain. Refresh manually and choose Always Allow to connect it."
        }
    }
}

/// Outcome of a credential load. `keychainPermissionRequired` means a Cursor Keychain item exists
/// but Runway isn't authorized to read it prompt-free yet — a real login footprint that only an
/// explicit manual refresh may convert into access.
enum CursorCredentialLoad: Equatable, Sendable {
    case state(CursorAuthState)
    case keychainPermissionRequired
    case none

    var state: CursorAuthState? {
        guard case .state(let state) = self else { return nil }
        return state
    }
}

struct CursorAuthStore: Sendable {
    static let stateDBPath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let accessTokenKey = "cursorAuth/accessToken"
    static let refreshTokenKey = "cursorAuth/refreshToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    static let keychainAccessTokenService = "cursor-access-token"
    static let keychainRefreshTokenService = "cursor-refresh-token"
    static let refreshBufferSeconds: TimeInterval = 5 * 60

    var sqlite: SQLiteAccessing
    var keychain: KeychainAccessing
    var now: @Sendable () -> Date

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.now = now
    }

    /// Keychain reads are in-process, never the `/usr/bin/security` subprocess: automatic refreshes
    /// use the prompt-free form, and only a manual refresh (`allowKeychainInteraction`) may raise
    /// the approval prompt — once, for Runway itself.
    func loadCredentials(allowKeychainInteraction: Bool = false) -> CursorCredentialLoad {
        // One `sqlite3` subprocess for all three keys instead of one per key — this runs on every
        // Cursor refresh, and each spawn costs a process launch plus pipe drains.
        let stateValues = readStateValues([
            Self.accessTokenKey, Self.refreshTokenKey, Self.membershipTypeKey,
        ])
        let sqliteAccessToken = stateValues[Self.accessTokenKey]
        let sqliteRefreshToken = stateValues[Self.refreshTokenKey]
        let sqliteMembershipType = stateValues[Self.membershipTypeKey]?.lowercased()

        let accessRead = readKeychainValue(Self.keychainAccessTokenService, allowInteraction: allowKeychainInteraction)
        let refreshRead = readKeychainValue(Self.keychainRefreshTokenService, allowInteraction: allowKeychainInteraction)
        let keychainAccessToken = accessRead.trimmedValue
        let keychainRefreshToken = refreshRead.trimmedValue

        let hasSQLiteAuth = sqliteAccessToken != nil || sqliteRefreshToken != nil
        let hasKeychainAuth = keychainAccessToken != nil || keychainRefreshToken != nil

        if hasSQLiteAuth {
            let sqliteSubject = Self.tokenSubject(sqliteAccessToken)
            let keychainSubject = Self.tokenSubject(keychainAccessToken)
            let subjectsDiffer = sqliteSubject != nil && keychainSubject != nil && sqliteSubject != keychainSubject
            if hasKeychainAuth, sqliteMembershipType == "free", subjectsDiffer {
                return .state(CursorAuthState(
                    accessToken: keychainAccessToken,
                    refreshToken: keychainRefreshToken,
                    source: .keychain
                ))
            }

            return .state(CursorAuthState(
                accessToken: sqliteAccessToken,
                refreshToken: sqliteRefreshToken,
                source: .sqlite
            ))
        }

        if hasKeychainAuth {
            return .state(CursorAuthState(
                accessToken: keychainAccessToken,
                refreshToken: keychainRefreshToken,
                source: .keychain
            ))
        }

        // No usable credential anywhere — but a protected keychain item is a real login footprint
        // (`hasLocalCredentials` must see it); only a manual refresh may convert it into access.
        // The existence probes are attributes-only and prompt-free.
        if accessRead == .unavailable || refreshRead == .unavailable,
           keychain.genericPasswordExists(service: Self.keychainAccessTokenService) == true
               || keychain.genericPasswordExists(service: Self.keychainRefreshTokenService) == true
        {
            return .keychainPermissionRequired
        }
        return .none
    }

    func needsRefresh(_ accessToken: String?) -> Bool {
        guard let accessToken,
              let expiresAt = Self.tokenExpiration(accessToken)
        else {
            return true
        }
        return expiresAt.timeIntervalSince(now()) <= Self.refreshBufferSeconds
    }

    func saveAccessToken(_ accessToken: String, source: CursorAuthState.Source) throws {
        switch source {
        case .sqlite:
            try writeStateValue(Self.accessTokenKey, accessToken)
        case .keychain:
            try keychain.writeGenericPassword(service: Self.keychainAccessTokenService, value: accessToken)
        }
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

    private func writeStateValue(_ key: String, _ value: String) throws {
        let sql = """
        INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('\(Self.sqlEscaped(key))', '\(Self.sqlEscaped(value))');
        """
        try sqlite.execute(path: Self.stateDBPath, sql: sql)
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
