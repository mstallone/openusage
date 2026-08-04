import XCTest
@testable import Runway

/// Cursor credential handling: which local source wins, what stays prompt-free, and how a lapsed or
/// rejected token is reported now that Runway never refreshes or writes Cursor's credentials.
final class CursorAuthStoreTests: XCTestCase {
    func testExpiredSQLiteTokenYieldsToAUsableSameAccountKeychainToken() {
        // Read-only means a lapsed selected token ends the refresh, so a usable token for the SAME
        // account must win instead of reporting renewal while a working credential sits unread.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredSQLite = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 - 60)
        let liveKeychain = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let store = CursorAuthStore(
            sqlite: FakeSQLite(values: [
                CursorAuthStore.accessTokenKey: expiredSQLite,
                CursorAuthStore.membershipTypeKey: "free"
            ]),
            keychain: ServiceKeychain(values: [
                CursorAuthStore.keychainAccessTokenService: liveKeychain
            ]),
            now: { now }
        )

        let state = store.loadCredentials().state

        XCTAssertEqual(state?.source, .keychain)
        XCTAssertEqual(state?.accessToken, liveKeychain)
    }

    func testExpiredPaidSQLiteLoginCanStillReachAProtectedKeychainToken() {
        // A usable paid SQLite login suppresses keychain prompts, but an EXPIRED one must not: the
        // protected item may hold this account's still-valid token, and it is the only thing that
        // can save the refresh. Automatic passes stay silent and report the approval need.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredSQLite = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 - 60)
        let liveKeychain = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let keychain = ApprovableCursorKeychain(approvedValue: liveKeychain)
        let store = CursorAuthStore(
            sqlite: FakeSQLite(values: [
                CursorAuthStore.accessTokenKey: expiredSQLite,
                CursorAuthStore.membershipTypeKey: "pro"
            ]),
            keychain: keychain,
            now: { now }
        )

        // Automatic: silent, and the protected item is surfaced as needing approval.
        XCTAssertEqual(store.loadCredentials(), .keychainPermissionRequired)
        XCTAssertEqual(keychain.interactiveReads, 0)

        // Manual: the prompt is allowed, and the same-account token wins over the dead one.
        let approved = store.loadCredentials(allowKeychainInteraction: true).state
        XCTAssertEqual(approved?.source, .keychain)
        XCTAssertEqual(approved?.accessToken, liveKeychain)
        XCTAssertEqual(keychain.interactiveReads, 1)
    }

    func testExpiredSQLiteTokenNeverCrossesToADifferentAccountsKeychainToken() {
        // The same fallback must not bridge accounts: a different subject keeps SQLite selected (a
        // paid membership here), so the card reports renewal for its own account instead of
        // silently showing another account's usage.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredSQLite = makeCursorJWT(sub: "auth0|user-a", exp: now.timeIntervalSince1970 - 60)
        let otherAccount = makeCursorJWT(sub: "auth0|user-b", exp: now.timeIntervalSince1970 + 3_600)
        let store = CursorAuthStore(
            sqlite: FakeSQLite(values: [
                CursorAuthStore.accessTokenKey: expiredSQLite,
                CursorAuthStore.membershipTypeKey: "pro"
            ]),
            keychain: ServiceKeychain(values: [
                CursorAuthStore.keychainAccessTokenService: otherAccount
            ]),
            now: { now }
        )

        let state = store.loadCredentials().state

        XCTAssertEqual(state?.source, .sqlite)
        XCTAssertEqual(state?.accessToken, expiredSQLite)
    }

    func testPrefersKeychainWhenSQLiteLooksFreeAndSubjectsDiffer() {
        let sqliteToken = makeCursorJWT(sub: "google-oauth2|sqlite-user")
        let keychainToken = makeCursorJWT(sub: "auth0|keychain-user")
        let sqlite = FakeSQLite(values: [
            CursorAuthStore.accessTokenKey: sqliteToken,
            CursorAuthStore.membershipTypeKey: "free"
        ])
        let keychain = ServiceKeychain(values: [
            CursorAuthStore.keychainAccessTokenService: keychainToken
        ])
        let store = CursorAuthStore(sqlite: sqlite, keychain: keychain)

        let state = store.loadCredentials().state

        XCTAssertEqual(state?.source, .keychain)
        XCTAssertEqual(state?.accessToken, keychainToken)
    }

}

@MainActor
final class CursorKeychainReadModeTests: XCTestCase {
    func testAutomaticKeychainLoadIsPromptFreeAndManualLoadMayPrompt() {
        // Regression for the 2026-08-03 prompt loop: Cursor's keychain items must never be read
        // through a prompt-capable path on an automatic refresh or at launch. Only a manual refresh
        // may use the interactive read (which prompts once, for Runway itself).
        let keychain = ReadModeTrackingKeychain(value: "cursor-token")
        let store = CursorAuthStore(sqlite: EmptySQLite(), keychain: keychain)

        XCTAssertEqual(store.loadCredentials().state?.accessToken, "cursor-token")
        XCTAssertEqual(keychain.interactiveReads, 0)
        XCTAssertGreaterThan(keychain.nonInteractiveReads, 0)
        XCTAssertEqual(keychain.plainReads, 0, "the subprocess-style read path must not be used")

        XCTAssertEqual(store.loadCredentials(allowKeychainInteraction: true).state?.accessToken, "cursor-token")
        XCTAssertGreaterThan(keychain.interactiveReads, 0)
        XCTAssertEqual(keychain.plainReads, 0)
    }

    func testProtectedKeychainItemsCountAsPermissionRequiredNotLoggedOut() {
        // A Cursor login stored only in protected Keychain items must be reported as
        // permission-required — a real footprint the user connects via manual refresh — never
        // silently collapsed into "not logged in".
        let store = CursorAuthStore(sqlite: EmptySQLite(), keychain: UnavailableCursorKeychain())

        XCTAssertEqual(store.loadCredentials(), .keychainPermissionRequired)
    }

    func testFreeSQLiteTokenDoesNotSilentlyBypassAProtectedKeychainLogin() {
        // The keychain (agent CLI) login can be the real paid account; with its items protected the
        // free-vs-different-subject comparison is impossible, so the load surfaces the approval need
        // instead of silently showing the free SQLite account. A paid SQLite login keeps winning.
        let sqlite = FakeSQLite(values: [
            CursorAuthStore.accessTokenKey: "sqlite-free-token",
            CursorAuthStore.membershipTypeKey: "free"
        ])
        let protected = CursorAuthStore(sqlite: sqlite, keychain: UnavailableCursorKeychain())
        XCTAssertEqual(protected.loadCredentials(), .keychainPermissionRequired)

        let paidSqlite = FakeSQLite(values: [
            CursorAuthStore.accessTokenKey: "sqlite-pro-token",
            CursorAuthStore.membershipTypeKey: "pro"
        ])
        let paid = CursorAuthStore(sqlite: paidSqlite, keychain: UnavailableCursorKeychain())
        XCTAssertEqual(paid.loadCredentials().state?.accessToken, "sqlite-pro-token")
    }

    func testManualRefreshWithAPaidSQLiteLoginNeverPromptsForStaleKeychainEntries() {
        // A paid SQLite login is returned unconditionally, so a manual refresh must not raise
        // approval dialogs for keychain entries it would then ignore.
        let sqlite = FakeSQLite(values: [
            CursorAuthStore.accessTokenKey: "sqlite-pro-token",
            CursorAuthStore.membershipTypeKey: "pro"
        ])
        let keychain = ReadModeTrackingKeychain(value: "stale-agent-token")
        let store = CursorAuthStore(sqlite: sqlite, keychain: keychain)

        let state = store.loadCredentials(allowKeychainInteraction: true).state

        XCTAssertEqual(state?.accessToken, "sqlite-pro-token")
        XCTAssertEqual(keychain.interactiveReads, 0, "keychain entries that cannot win must not prompt")
    }

}

private final class EmptySQLite: SQLiteAccessing, @unchecked Sendable {
    func queryValue(path: String, sql: String) throws -> String? { nil }
    func queryJSONRows(path: String, sql: String) throws -> String? { nil }
    func execute(path: String, sql: String) throws {}
}

/// Cursor keychain items Runway isn't authorized to read prompt-free: non-interactive reads report
/// `.unavailable` while the attributes-only existence probe still confirms the items.
private final class UnavailableCursorKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the subprocess-style read path must not be used")
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func genericPasswordExists(service: String) -> Bool? {
        true
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

@MainActor
final class CursorReadOnlyCredentialTests: XCTestCase {
    func testExpiredTokenNeverRefreshesOrWritesAndReportsRenewal() async {
        // Runway is a read-only consumer of Cursor's credentials: an expired token means NO
        // token-endpoint call, NO state-database or keychain write, and a renewal notice.
        let sqlite = FakeSQLite(values: [
            CursorAuthStore.accessTokenKey: makeCursorJWT(exp: 1),
            CursorAuthStore.membershipTypeKey: "pro"
        ])
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: sqlite, keychain: FakeKeychain()),
            usageClient: CursorUsageClient(http: http)
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(http.requests.isEmpty, "an expired token short-circuits before any network call")
        XCTAssertTrue(sqlite.writtenValues.isEmpty, "Cursor's state database is never written by Runway")
        XCTAssertEqual(
            snapshot.lines.compactMap { line -> String? in
                guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
                return text
            }.first,
            CursorAuthError.loginRenewalRequired.localizedDescription
        )
    }

    func testUsage401ReportsRenewalWithoutARetryOrTokenEndpointCall() async {
        let sqlite = FakeSQLite(values: [
            CursorAuthStore.accessTokenKey: makeCursorJWT(),
            CursorAuthStore.membershipTypeKey: "pro"
        ])
        let http = RoutingHTTPClient { request in
            XCTAssertFalse(
                request.url.absoluteString.contains("token"),
                "the token endpoint must never be contacted"
            )
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: sqlite, keychain: FakeKeychain()),
            usageClient: CursorUsageClient(http: http)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(http.requests.count, 1, "no refresh-and-retry: one usage call, then renewal")
        XCTAssertEqual(
            snapshot.lines.compactMap { line -> String? in
                guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
                return text
            }.first,
            CursorAuthError.loginRenewalRequired.localizedDescription
        )
    }
}

@MainActor
final class CursorPromptBoundTests: XCTestCase {
    func testDeniedAccessPromptDoesNotRaiseTheRefreshPromptToo() {
        // Approval is per item, but a denial of the first prompt means "no" — the companion item's
        // prompt must not follow in the same pass.
        let keychain = DenyingCursorKeychain()
        let store = CursorAuthStore(sqlite: EmptySQLite(), keychain: keychain)

        XCTAssertEqual(store.loadCredentials(allowKeychainInteraction: true), .keychainPermissionRequired)
        XCTAssertEqual(keychain.interactiveReads, 1, "a denial must not chain into a second prompt")
    }
}

/// Every interactive read is denied (throws); non-interactive reads report items as protected.
private final class DenyingCursorKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private var interactive = 0

    var interactiveReads: Int { lock.withLock { interactive } }

    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the subprocess-style read path must not be used")
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String? {
        lock.withLock { interactive += 1 }
        throw KeychainError.readFailed("denied")
    }

    func genericPasswordExists(service: String) -> Bool? {
        true
    }
}

/// A protected Cursor keychain item that becomes readable once the user approves the prompt.
private final class ApprovableCursorKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private let approvedValue: String
    private var interactive = 0

    init(approvedValue: String) {
        self.approvedValue = approvedValue
    }

    var interactiveReads: Int { lock.withLock { interactive } }

    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the subprocess-style read path must not be used")
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String? {
        lock.withLock { interactive += 1 }
        return approvedValue
    }

    func genericPasswordExists(service: String) -> Bool? {
        true
    }
}

@MainActor
final class CursorRevokedTokenFallbackTests: XCTestCase {
    func testServerRejectionRetriesTheSameAccountKeychainTokenOnce() async {
        // An unexpired SQLite token that the server revoked (signed out elsewhere). Runway can't
        // refresh it, but the agent CLI's keychain copy for the SAME account is still live — it must
        // be tried once instead of reporting renewal while a working credential sits unread.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let revoked = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let live = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let http = RoutingHTTPClient { request in
            XCTAssertFalse(request.url.absoluteString.contains("oauth/token"), "no OAuth token-endpoint call may be made")
            guard request.headers["Authorization"]?.contains(live) == true else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"enabled":true,"planUsage":{"limit":40000,"totalPercentUsed":20}}"#.utf8)
            )
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeSQLite(values: [
                    CursorAuthStore.accessTokenKey: revoked,
                    CursorAuthStore.membershipTypeKey: "pro"
                ]),
                keychain: ServiceKeychain(values: [
                    CursorAuthStore.keychainAccessTokenService: live
                ]),
                now: { now }
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(
            snapshot.lines.compactMap { line -> String? in
                guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
                return text
            }.first,
            "the live same-account token should have served this refresh"
        )
    }

    func testAlternativeCredentialsNetworkFailureIsNotReportedAsRenewal() async {
        // The selected token was rejected and the same-account alternative hit a server error.
        // Telling the user to sign in again over a Cursor outage would send them down the wrong
        // path — the alternative may be perfectly valid.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let revoked = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let live = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let http = RoutingHTTPClient { request in
            guard request.headers["Authorization"]?.contains(live) == true else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeSQLite(values: [
                    CursorAuthStore.accessTokenKey: revoked,
                    CursorAuthStore.membershipTypeKey: "pro"
                ]),
                keychain: ServiceKeychain(values: [
                    CursorAuthStore.keychainAccessTokenService: live
                ]),
                now: { now }
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        let error = snapshot.lines.compactMap { line -> String? in
            guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
            return text
        }.first
        XCTAssertEqual(error, ProviderUsageErrorText.requestFailed(statusCode: 503))
        XCTAssertNotEqual(error, CursorAuthError.loginRenewalRequired.localizedDescription)
    }

    func testServerRejectionDoesNotRetryADifferentAccountsToken() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let revoked = makeCursorJWT(sub: "auth0|user-a", exp: now.timeIntervalSince1970 + 3_600)
        let otherAccount = makeCursorJWT(sub: "auth0|user-b", exp: now.timeIntervalSince1970 + 3_600)
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeSQLite(values: [
                    CursorAuthStore.accessTokenKey: revoked,
                    CursorAuthStore.membershipTypeKey: "pro"
                ]),
                keychain: ServiceKeychain(values: [
                    CursorAuthStore.keychainAccessTokenService: otherAccount
                ]),
                now: { now }
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(http.requests.count, 1, "another account's token must never be tried")
        XCTAssertEqual(
            snapshot.lines.compactMap { line -> String? in
                guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
                return text
            }.first,
            CursorAuthError.loginRenewalRequired.localizedDescription
        )
    }
}

@MainActor
final class CursorExpiredKeychainPreferenceTests: XCTestCase {
    func testFreeSQLiteLoginIsKeptWhenTheAgentTokenHasExpired() {
        // The agent login usually is the paid account and wins a free SQLite membership — but not
        // when it's expired, because Runway can't refresh it and would trade live data for a
        // renewal notice.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let liveSQLite = makeCursorJWT(sub: "auth0|free-user", exp: now.timeIntervalSince1970 + 3_600)
        let expiredAgent = makeCursorJWT(sub: "auth0|paid-user", exp: now.timeIntervalSince1970 - 60)
        let store = CursorAuthStore(
            sqlite: FakeSQLite(values: [
                CursorAuthStore.accessTokenKey: liveSQLite,
                CursorAuthStore.membershipTypeKey: "free"
            ]),
            keychain: ServiceKeychain(values: [
                CursorAuthStore.keychainAccessTokenService: expiredAgent
            ]),
            now: { now }
        )

        let state = store.loadCredentials().state

        XCTAssertEqual(state?.source, .sqlite)
        XCTAssertEqual(state?.accessToken, liveSQLite)
    }
}

private func makeCursorJWT(sub: String = "google-oauth2|user", exp: Double = 9_999_999_999) -> String {
    let payload = #"{"sub":"\#(sub)","exp":\#(exp)}"#
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "a.\(encoded).c"
}

private final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var values: [String: String]
    private(set) var writtenValues: [String: String] = [:]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func queryValue(path: String, sql: String) throws -> String? {
        let matches = values.filter { sql.contains("'\($0.key)'") }
        guard !matches.isEmpty else { return nil }
        let object = matches.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        return "{\(object)}"
    }

    func queryJSONRows(path: String, sql: String) throws -> String? { nil }
}
